// eth-producer-facts.mjs — THE FACTS THE ETHEREUM MAINNET PRODUCER STATES ABOUT THE
// CHAIN IT CAPTURES.
//
// ── WHY THIS FILE IS A CLONE AND NOT A PARAMETERISATION ───────────────────────────────
//
// `producer-facts.mjs` — this file's older sibling — says in its own header what to do
// here, and this file is that instruction carried out verbatim:
//
//     "This is a data module for ONE producer, not an interface over producers. There is
//      no registry, no dispatch and no second implementation: a second chain's recorder
//      is a separate tool with a file like this one of its own, and the only thing the
//      two share is the snapshot format they both write."
//
// So this is a SECOND data module, not a widening of the first. Nothing imports both,
// nothing selects between them, and there is no type, base object or table that ranges
// over the two. The duplication is the mechanism: Chain-Delivery DEL-7 is the milestone
// that may extract a seam from these two files, and it is allowed to do so only once
// there are two real consumers to measure the seam against (ING-7's two-consumer rule).
// A seam guessed from one producer is the thing that campaign exists to avoid.
//
// ── WHAT DIFFERS FROM THE AZTEC MODULE, MEMBER BY MEMBER ──────────────────────────────
//
// Recorded here because the differences are the evidence DEL-7 will read, and a
// difference nobody wrote down is a difference the extraction will flatten:
//
//   * `RECORDER.traceSchema` is `ctfs/v5` where Aztec's is `ctfs/v4`, and the digit is
//     read out of the container's own header bytes rather than chosen — see the
//     producer's `containerVersion()`.
//   * `PRESTATE_STRATEGY` is `replay-preceding`, Chain-Support-Matrix.md §1.4's token for
//     "pin the parent block and re-execute indices 0..k-1". Aztec's is
//     `hydrated-from-node`. Both are members of the same closed set.
//   * THE COST VECTOR HAS TWO DIMENSIONS, NOT ONE. Aztec charges one settled fee and its
//     vector has one entry with `limit` and `price` empty, because "this chain's receipts
//     carry neither". Ethereum's receipts carry BOTH — a gas limit the sender set and an
//     effective price the protocol computed — and a type-3 (EIP-4844) transaction carries
//     a SECOND dimension, blob gas, priced independently of execution gas. This is the
//     chain Data-Contract.md §5.3 had in mind when it wrote "a chain with two fee
//     dimensions", and it is why the reader must supply no name, unit or token.
//   * The execution partition has one entry whose selector is `transaction`, and the word
//     is load-bearing: an Ethereum transaction is ONE top-level message call, so there is
//     no public/private split for a selector to name. Aztec's `public` selects one half
//     of a transaction that has two.
//   * There are no machine columns to subtract from a frame's arguments. Aztec's
//     `AVM_MACHINE_COLUMNS` exists because the AVM stamps five VM registers onto every
//     `Call` event's `args`; the EVM container interns two variable names and they are
//     the two storage slots the transaction touched, which are not machine registers and
//     are not attached to frames.
//
// ── THE POSITION LANGUAGE IS NOT A LANGUAGE NAME, AND THAT IS MEASURED ────────────────
//
// Aztec states `noir` because its proved artifacts carry Noir source. On this chain the
// address this capture entered is verified on Sourcify with solc 0.4.18, the dev shell
// ships 0.8.33, and solc refuses the source outright — so no `srcmap-runtime` exists and
// nothing maps a program counter to a Solidity span. What the recorder registered instead
// is a DISASSEMBLY LISTING of the bytecode deployed at the target block, one line per
// instruction, and the positions in the container point at that. `evm-disassembly` is
// therefore the honest answer: the positions are real, they are not Solidity, and calling
// them `solidity` would publish a claim the toolchain could not make.

/** `provenance.recorder` — who recorded this capture's executions, and in what schema. */
export const RECORDER = Object.freeze({ id: 'ethereum-evm', traceSchema: 'ctfs/v5' });

/** `provenance.prestateStrategy` — one of Chain-Support-Matrix.md §1.4's six. */
export const PRESTATE_STRATEGY = 'replay-preceding';

/** A source bundle's `language` — what this capture's positions are written in. */
export const POSITION_LANGUAGE = 'evm-disassembly';

/** A position stream's own `schema` token, republished verbatim by the reader. */
export const POSITION_STREAM_SCHEMA = 'evm-disassembly-positions/1';

/** The instruction listing's own `schema` token. */
export const INSTRUCTION_STREAM_SCHEMA = 'evm-instructions/1';

/** The call-trace stream's own `schema` token. */
export const CALLTRACE_STREAM_SCHEMA = 'evm-call-frames/1';

/**
 * `sidecar:instructions.isa` — the instruction set this listing's opcodes are opcodes in,
 * carried up to the chain's registry row as `vm.instructionSet`.
 *
 * `evm` AND NOT `ethereum-evm`, deliberately. The ISA is the thing that selects a mnemonic
 * table, and the EVM's table is the same on Base, Arbitrum and every other EVM instance —
 * so a token that named the CHAIN would make each instance select a table of its own and
 * would be wrong about the one fact the member exists to state. The recorder's id is
 * chain-qualified because a build is a build of one producer; the instruction set is not.
 */
export const INSTRUCTION_SET = 'evm';

/**
 * `transactions[].executions` — this chain's execution partition.
 *
 * ONE ENTRY, and `reason` is a parameter rather than an omission. An entry WITHOUT a
 * reason is the one the row's container is a recording of (Data-Contract.md §5.3), so a
 * row this producer did not trace states the reason on its single entry and leaves none
 * unreasoned. The Aztec producer leaves its entry unreasoned on untraced rows too, which
 * conforms — `S5-EXECUTIONS-ONE-TRACED` bounds the unreasoned entries at one — but it
 * says of a row with no container that its container belongs to that execution.
 *
 * A fresh array per call: the row it goes into is mutated by later passes, and a frozen
 * shared literal would make two rows the same object.
 */
export const executionsForRow = (reason) => (reason
  ? [{ selector: 'transaction', reason }]
  : [{ selector: 'transaction' }]);

/**
 * `transactions[].cost` — the VECTOR Static-Site-Architecture.md §2.3 defines, for one
 * row, from the figures the receipt and the transaction carry.
 *
 * TWO DIMENSIONS WHERE THE CHAIN HAS TWO. Execution gas is always present. Blob gas is
 * present exactly on a transaction that carries blobs, and its `used` and `price` come
 * from the receipt's own `blobGasUsed` / `blobGasPrice` — so a chain with two fee
 * dimensions states two entries and a reader that had named one would have had no way to
 * express the second.
 *
 * `limit` is the sender's own ceiling and `price` the protocol's computed figure; both are
 * real on this chain, unlike Aztec's, where they are stated empty because the receipts
 * carry neither. `refundable` is `false` on both: the gas not used is never charged in the
 * first place, so there is nothing to refund — which is a different fact from a chain that
 * charges and then refunds, and the member says so.
 *
 * An absent figure becomes an empty string rather than being dropped, because `used` is
 * required: a cost entry with no figure at all is a dimension nothing can read.
 */
export const costVectorForRow = ({ gasUsed, gasLimit, effectiveGasPrice,
                                   blobGasUsed, blobGasPrice } = {}) => {
  const v = [{
    name: 'gas',
    used: gasUsed ?? '',
    limit: gasLimit ?? '',
    price: effectiveGasPrice ?? '',
    unit: 'gas',
    token: 'ETH',
    refundable: false,
  }];
  if (blobGasUsed !== undefined && blobGasUsed !== null) {
    v.push({
      name: 'blobGas',
      used: blobGasUsed,
      limit: '',
      price: blobGasPrice ?? '',
      unit: 'blob-gas',
      token: 'ETH',
      refundable: false,
    });
  }
  return v;
};
