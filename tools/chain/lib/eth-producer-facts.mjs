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
// DEL-7: the one `*ForRow` helper all five chains had byte-identically (5 definitions,
// 1 distinct text, against 5-in-5 for `costVectorForRow` and `rolesForRow`). The shared
// implementation is `lib/producer-runtime.mjs`; the export keeps its contract name here,
// so this module stays the one place a producer imports its row shapes from.
export { oneExecutionPerTransaction as executionsForRow } from './producer-runtime.mjs';

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

/**
 * `transactions[].roles` — WHO this chain says acted, as Static-Site-Architecture.md §2.3's
 * role list.
 *
 * ── WHY THIS EXISTS: THE COLUMN WAS A DASH ON EVERY ROW ───────────────────────────────
 *
 * The shared transactions table has carried `From`, `To / target` and `Method` columns
 * since before this chain was ingested, and this producer published no roles and no
 * payload, so all three rendered the em dash on all 208 rows of the one block this capture
 * holds — measured on the exported site: 624 muted em-dash cells, 208 × 3. `tables.nim`'s
 * `addressCell` renders that dash with the comment "§2.3: some chains have no sender at
 * all. An em dash is the honest rendering of a role this chain family does not have — it
 * is not a missing value." On Ethereum it was a missing value wearing that sentence, which
 * is the one thing the sentence promises it is not.
 *
 * ONE ROLE, AND THE WORD IS `sender`. An Ethereum transaction is signed by exactly one
 * externally-owned account, and that account is the signer, the fee payer and the initiator
 * at once — there is no separate payer to name (no EIP-7702 sponsor, no paymaster, no
 * fee-delegation on L1 today) and publishing three role entries with one address would
 * state three independent facts where the chain has one. `reader.nim`'s `txRow` already
 * accepts this spelling: it looks for a role in `["feePayer", "signer", "initiator",
 * "sender"]` to fill the `From` column.
 *
 * `from` IS ALWAYS PRESENT ON A SETTLED TRANSACTION, and an absent one yields NO role
 * rather than an empty address: an entry whose `address` is `""` would render as a link to
 * nowhere, where no entry at all renders the honest dash the cell already has.
 *
 * @param {{from?: string}} tx  the full transaction object, as `eth_getBlockByNumber`
 *                              with `true` returns it
 * @returns {{role: string, address: string}[]}
 */
export const rolesForRow = (tx) => (tx?.from
  ? [{ role: 'sender', address: tx.from.toLowerCase() }]
  : []);

/**
 * `transactions[].payload` — WHAT was called, as the `target` and `selector` the explorer's
 * `To / target` and `Method` columns are of.
 *
 * ── THE SELECTOR IS THE FIRST FOUR BYTES, AND IT IS SHOWN RATHER THAN RESOLVED ────────
 *
 * The EVM's calling convention puts a 4-byte function selector at the head of a non-empty
 * calldata, and nothing in this repository can turn one into a signature: that needs an ABI
 * registry, and this producer reaches no network beyond the committed transcript. So the
 * selector is published as the four bytes it is. An unresolved `0x23b872dd` tells a reader
 * which method was called — two transactions carrying it called the same one — and a dash
 * tells them nothing at all. Resolving it to `transferFrom(address,address,uint256)` is a
 * strictly later improvement and needs a signature set whose keccak this tool can check.
 *
 * A CALLDATA SHORTER THAN FOUR BYTES HAS NO SELECTOR, AND THAT IS NOT A MISSING ONE. 45 of
 * this block's 208 transactions carry `input: "0x"` — plain value transfers, which call no
 * method. They publish an empty selector and the `Method` cell keeps its dash, which is the
 * honest rendering: there is nothing there to name. Truncating or zero-padding a short
 * calldata into a selector would invent a method call.
 *
 * `target` IS `to`, AND A CONTRACT CREATION HAS NONE. `to` is `null` exactly on a creation,
 * and the address that comes into existence is in the RECEIPT (`contractAddress`) — an
 * OUTPUT of the transaction rather than the thing it was aimed at. Publishing it as
 * `target` would be the one kind of wrong this member can be: confident and plausible. So a
 * creation publishes an empty target. THIS SHAPE HAS NO INSTANCE IN THE COMMITTED CAPTURE —
 * all 208 transactions in block 26,083,328 carry a `to` — so the branch is reasoned rather
 * than measured, and it is written to publish nothing rather than to guess.
 *
 * @param {{to?: string|null, input?: string}} tx  the full transaction object
 * @returns {{raw: string, selector: string, target: string}}
 */
export const payloadForRow = (tx) => {
  const input = typeof tx?.input === 'string' ? tx.input.toLowerCase() : '';
  // `0x` + 8 hex digits = 4 bytes. Shorter carries no selector; see above.
  const selector = /^0x[0-9a-f]{8}/.test(input) ? input.slice(0, 10) : '';
  return {
    // ── `raw` IS DELIBERATELY EMPTY, AND THE REASON IS MEASURED ────────────────────
    //
    // The transaction page renders this member into ONE copyable metadata row with no
    // fold and no cap: `.identifier` is `word-break:break-all`, so a long value wraps
    // rather than overflowing, and nothing bounds its height. Measured over the 208
    // transactions of block 26,083,328 — the whole of the committed capture:
    //
    //     median 138 chars · p90 2,826 · max 21,514
    //     28 of 208 (13%) over 2,000 chars  (~25 rendered lines)
    //     12 of 208  (6%) over 5,000 chars  (~62 lines)
    //      2 of 208  (1%) over 10,000 chars (up to ~268 lines)
    //
    // So publishing it would fill one row on 100% of transaction pages and put a
    // 25-line-plus hex block into the facts grid of 13% of them. That is trading one
    // honest em dash for a page defect on one in eight pages, and the row the dash sits
    // in already reads correctly: with the selector present and the call data absent the
    // page says "This selector is not in any ABI BlockTracer holds, and no call data
    // accompanies it here, so there are no parameters to decode."
    //
    // The member stays in the shape because §5.2's `payload` names it, and filling it is
    // waiting on ONE thing: a `Raw` row that can fold. It has to fold without script —
    // this route ships no JavaScript, which is the same constraint that rules out the
    // "supply an ABI" action two sentences above it — so the remedy is a CSS-only
    // disclosure (`<details>`), not a truncation, because a silently cut calldata is
    // worse than none.
    raw: '',
    selector,
    target: typeof tx?.to === 'string' ? tx.to.toLowerCase() : '',
  };
};
