// producer-facts.mjs — THE FACTS THIS PRODUCER STATES ABOUT THE CHAIN IT CAPTURES.
//
// ── WHY THIS FILE EXISTS, AND WHY IT IS ON THIS SIDE OF THE SEAM ──────────────────────
//
// Six facts used to be `const`s inside `src/blocktracer/chain/ingest.nim` — the reader.
// Each was a statement about ONE chain compiled into the consumer of EVERY chain, so a
// second producer would have had to overwrite them rather than supply them. They are
// listed in `Data-Contract.md` §5.3 and they are, exactly: the recorder's identity, the
// trace schema it writes, the language a source bundle's positions are written in, the
// cost vector, the prestate strategy, and the execution selector.
//
// They were always facts about the capture rather than about the reader, so this is where
// they belong: beside the tools that talk to the node. `capture-chain.mjs` and
// `follow-chain.mjs` are already this chain's producers — they call this chain's RPC
// methods, load its VM module, and shell out to its recorder — so naming the chain here
// costs nothing and hides nothing. Naming it in the reader cost a whole seam.
//
// ── WHAT IS DELIBERATELY NOT ABSTRACTED HERE ──────────────────────────────────────────
//
// This is a data module for ONE producer, not an interface over producers. There is no
// registry, no dispatch and no second implementation: a second chain's recorder is a
// separate tool with a file like this one of its own, and the only thing the two share is
// the snapshot format they both write. That is the whole point of the seam being a
// filesystem layout rather than a code boundary.
//
// ── TWO COST FIELDS ARE DELIBERATELY EMPTY ────────────────────────────────────────────
//
// `limit` and `price` are stated as empty strings rather than omitted, because this chain's
// receipts carry neither: the fee is a settled figure and there is no published ceiling or
// per-unit price to report. An empty string is "the producer looked and there is none",
// which is what the published object should say; omitting them would be indistinguishable
// from a producer that never considered the question.

/** `provenance.recorder` — who recorded this capture's executions, and in what schema. */
export const RECORDER = Object.freeze({ id: 'aztec-avm', traceSchema: 'ctfs/v4' });

/** `provenance.prestateStrategy` — one of Chain-Support-Matrix.md §1.4's six. */
export const PRESTATE_STRATEGY = 'hydrated-from-node';

/** A source bundle's `language` — what this chain's proved artifacts' positions are in. */
export const POSITION_LANGUAGE = 'noir';

/** A position stream's own `schema` token, republished verbatim by the reader. */
export const POSITION_STREAM_SCHEMA = 'avm-source-positions/1';

/**
 * `transactions[].executions` — this chain's execution partition, as this producer
 * observes it. One entry, and the absence of a `reason` on it is what tells the reader
 * that the row's container is a recording of THIS execution.
 *
 * A fresh array per call: the row it goes into is mutated by later passes, and a frozen
 * shared literal would make two rows the same object.
 */
export const executionsForRow = () => [{ selector: 'public' }];

/**
 * `transactions[].cost` — the VECTOR Static-Site-Architecture.md §2.3 defines, for one
 * row. This chain charges in one dimension, so the vector has one entry; a chain with two
 * would state two and the reader carries whatever it is handed.
 *
 * `fee` is the chain's own figure, as the receipt reported it. An absent figure becomes
 * an empty string rather than being dropped, because `used` is required: a cost entry
 * with no figure at all is a dimension nothing can read.
 */
export const costVectorForRow = (fee) => [{
  name: 'transactionFee',
  used: fee ?? '',
  limit: '',
  price: '',
  unit: 'mana',
  token: 'FeeJuice',
  refundable: false,
}];

/**
 * THE VM'S MACHINE COLUMNS — the five variable names an AVM container interns, which are
 * a fact about the VIRTUAL MACHINE and not about any Noir function.
 *
 * ── WHY THIS LIST EXISTS ────────────────────────────────────────────────────────────────
 *
 * The recorder attaches these to the step stream and to every `Call` event, so a consumer
 * that reads a `Call`'s `args` straight through publishes them as the CALLEE'S ARGUMENTS.
 * That is what `calltrace.json` did: across the 47 frames of
 * `aztec-testnet-frames/0x0a807e4e…` there were exactly three distinct `args` lists and
 * 45 of 47 were the same one — `[{ "name": "contractAddress", "value": "0x…03" }]` — so
 * `Reader<N>::read`, `<impl Add for u128>::add`, `poseidon2_permutation` and
 * `Option<T>::unwrap` were all published as taking a `contractAddress` argument. None of
 * them does. It is the contract whose context the frame ran in, stamped onto every frame,
 * and it is the "plausible but wrong" shape: nothing about it looks like an absence.
 *
 * The information is real and is NOT discarded — it moves to `contractAddress` on the
 * frame, where it says what it is. What `args` publishes afterwards is the empty list,
 * which is the truth: these contracts are compiled with `debug_info.variables` empty
 * (measured on the FeeJuice artifact this transaction proved), so no function's arguments
 * were ever captured.
 *
 * ── WHY A NAMED SET AND NOT A HEURISTIC ─────────────────────────────────────────────────
 *
 * "An argument list identical on every frame is not an argument list" was considered and
 * is FALSE of this corpus — `<toplevel>` carries none and `context2` carries the second
 * contract's address — so a same-on-every-frame rule would have declined to fire on the
 * very recording that motivated it. These five are what the container declares
 * (`VariableName` records, measured: `contractAddress`, `opcode`, `contextId`, `l2Gas`,
 * `daGas`, in both containers that carry positions), they are declared here where this
 * chain's other producer facts are declared, and `calltrace-fold-selftest.mjs` asserts the
 * split fires on each of them and on nothing else.
 */
export const AVM_MACHINE_COLUMNS = Object.freeze([
  'contractAddress', 'opcode', 'contextId', 'l2Gas', 'daGas',
]);

/** The machine column a frame's execution CONTEXT is named by, promoted out of `args`. */
export const FRAME_CONTEXT_COLUMN = 'contractAddress';
