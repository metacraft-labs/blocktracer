// sui-producer-facts.mjs — the facts a Sui producer states about its capture.
//
// The Sui twin of `eth-producer-facts.mjs`, and deliberately a DUPLICATE of its shape
// rather than an instance of a shared seam: ING-7's two-consumer rule (Chain-Delivery
// DEL-7) forbids extracting the seam until a second and third producer have shipped
// without it. Everything here is something the snapshot carries as DATA (Data-Contract.md
// §5.3) that a reader must not assume; the producer imports it rather than spelling it,
// which `lib/producer-scan.mjs` R1–R4 checks.

/** `provenance.chain` — Chain-Support-Matrix.md §4's slug for Sui. Slugs never change. */
export const CHAIN_SLUG = 'sui';

/**
 * `provenance.recorder` — `codetracer-move-recorder` converting a `sui replay --trace`
 * into a CTFS container. The container version is 5 (header byte 6), as for the EVM
 * recorder: both write through the same Nim trace writer.
 */
export const RECORDER = Object.freeze({ id: 'sui-move', traceSchema: 'ctfs/v5' });

/**
 * `provenance.prestateStrategy` — Chain-Support-Matrix.md §1.4. A Sui transaction names
 * the exact object versions it consumed, and `sui replay` fetches exactly those by version;
 * nothing is re-executed to obtain state and no block before it is replayed.
 */
export const PRESTATE_STRATEGY = 'version-addressed';

/**
 * `provenance.identifierEncoding` — per KIND, as Search-And-Routing.md §2 classifies them.
 * A Sui digest (transaction and checkpoint alike) is the base58 spelling of 32 bytes; an
 * address is `0x` + 64 hex. Base58 is case-significant, so its shard key is folded and
 * its leaf preserved (`identifier-encodings.json`); see codetracer-pm
 * issues/2026-10-20-sui-digests-are-base58-not-base64.md for why this is not base64.
 */
export const IDENTIFIER_ENCODING = Object.freeze({
  transaction: 'base58',
  block: 'base58',
  address: 'hex',
});

/**
 * The first protocol version whose execution layer emits trace events. Sui selects an
 * execution layer per protocol version (`sui-execution/src/lib.rs`); layers v0–v2 carry
 * no trace hooks and v3 — first selected at protocol 38
 * (`crates/sui-protocol-config/src/lib.rs`, the `38 =>` arm) — is the first that does.
 * Measured on mainnet 2026-10-20 with sui 1.81.1: checkpoint 28,845,200 (epoch 337,
 * protocol 36) replays with a header-only trace; 28,845,500 (epoch 338, protocol 38)
 * replays with 492,189 trace lines. A producer reads the boundary's checkpoint off the
 * chain; this constant is the protocol version that defines it, not the checkpoint.
 */
export const MIN_TRACED_PROTOCOL = 38;

/** A source bundle's `language` — positions are lines of a Move bytecode disassembly. */
export const POSITION_LANGUAGE = 'move-disassembly';

/** A position stream's own `schema` token, republished verbatim by the reader. */
export const POSITION_STREAM_SCHEMA = 'move-disassembly-positions/1';

/** The call-trace stream's own `schema` token. */
export const CALLTRACE_STREAM_SCHEMA = 'move-call-frames/1';

/** The instruction set the positions index into. */
export const INSTRUCTION_SET = 'move';

/**
 * `executions[]`. One execution per transaction, whose selector names the whole
 * programmable transaction block. Whether a PTB is one execution or one per command is
 * CXP-MOVE-4's decision to take and record; until it is taken this states the coarse
 * partition rather than defaulting to the fine one, and the commands are recorded inside
 * the container as `MovePtbCommand` events either way.
 */
// DEL-7: the one `*ForRow` helper all five chains had byte-identically (5 definitions,
// 1 distinct text, against 5-in-5 for `costVectorForRow` and `rolesForRow`). The shared
// implementation is `lib/producer-runtime.mjs`; the export keeps its contract name here,
// so this module stays the one place a producer imports its row shapes from.
export { oneExecutionPerTransaction as executionsForRow } from './producer-runtime.mjs';

/**
 * `cost[]` — Sui's gas summary is FOUR figures, not one, and the storage rebate is
 * returned to the payer: it is published as its own negative-signed entry rather than as
 * a subtraction the reader performs (Recorder-Move CXP-MOVE-2). Units are MIST
 * (10^-9 SUI). Figures are the decimal strings the service published.
 */
export const costVectorForRow = ({ computationCost, storageCost, storageRebate,
                                   nonRefundableStorageFee, gasPrice, gasBudget } = {}) => [
  {
    name: 'computation',
    used: String(computationCost ?? ''),
    limit: String(gasBudget ?? ''),
    price: String(gasPrice ?? ''),
    unit: 'MIST',
    token: 'SUI',
    refundable: false,
  },
  { name: 'storage', used: String(storageCost ?? ''), unit: 'MIST', token: 'SUI',
    refundable: true },
  { name: 'storageRebate',
    used: storageRebate === undefined || storageRebate === null
      || String(storageRebate) === '0' ? '0' : `-${storageRebate}`,
    unit: 'MIST', token: 'SUI', refundable: false },
  { name: 'nonRefundableStorageFee', used: String(nonRefundableStorageFee ?? ''),
    unit: 'MIST', token: 'SUI', refundable: false },
];

/**
 * `roles[]` — Static-Site-Architecture.md §2.3 lists `sender`, `sponsor` and `feePayer` as
 * distinct roles precisely for sponsored transactions, where the gas owner is not the
 * sender. The gas owner is always the fee payer; it is also a sponsor when it differs from
 * the sender. A system transaction has neither and publishes no role.
 */
export const rolesForRow = (tx) => {
  const roles = [];
  // A system transaction's sender and gas owner are the zero address (`@0x0`): nobody
  // sent it and nobody paid, so it publishes no role rather than a link to `0x0…0`.
  const someone = (a) => (typeof a === 'string' && !/^0x0*$/.test(a) ? a : null);
  const sender = someone(tx?.sender);
  const payer = someone(tx?.gasSponsor ?? tx?.transactionJson?.gasPayment?.owner ?? null);
  if (sender) roles.push({ role: 'sender', address: sender });
  if (payer) {
    if (sender && payer !== sender) roles.push({ role: 'sponsor', address: payer });
    roles.push({ role: 'feePayer', address: payer });
  }
  return roles;
};

/**
 * `payload` — what the transaction asked for. For a programmable transaction block the
 * selector is its first command (`<package>::<module>::<function>` for a Move call, the
 * command's kind otherwise) and the target is that call's package; other kinds name
 * themselves.
 */
export const payloadForRow = (tx) => {
  const ptb = tx?.transactionJson?.kind?.programmableTransaction;
  const first = ptb?.commands?.[0];
  if (first?.moveCall) {
    const { package: pkg, module, function: fn } = first.moveCall;
    return { raw: '', selector: `${pkg}::${module}::${fn}`, target: pkg };
  }
  if (first) return { raw: '', selector: Object.keys(first)[0] ?? '', target: '' };
  return { raw: '', selector: tx?.kind ?? '', target: '' };
};

/**
 * `provenance.reachReason` — why history starts at `replayableFrom`. On Sui the floor is the
 * first checkpoint at protocol MIN_TRACED_PROTOCOL, an EXECUTION-LAYER limit: below it a
 * transaction replays but writes no trace. It is not a state limit — prestate is
 * version-addressed and the endpoint serves object contents much further down — so the
 * reader's generic "prestate was obtainable from …" sentence would state the wrong cause.
 * `deepestServed` is the committed endpoint-horizon reading's deepest served checkpoint
 * (`measurements/sui-endpoint-horizon.json`), or null when it states none.
 */
export const reachReasonFor = (floorCheckpoint, deepestServed) =>
  `checkpoint ${floorCheckpoint} is the first at protocol version ${MIN_TRACED_PROTOCOL}, the `
  + 'first Sui execution layer with trace hooks; a transaction below it still replays but '
  + 'writes no trace. The chain\'s state is not the limit: each transaction names the exact '
  + 'object versions it consumed, and the GraphQL service '
  + (deepestServed === null
    ? 'serves their contents below this checkpoint as well'
    : `served their contents down to checkpoint ${deepestServed} when last measured`);

/** `provenance.verification` — what each trace is compared against, and the refusal. */
export const VERIFICATION = 'each transaction is re-executed by `sui replay` from the exact '
  + 'object versions it consumed and compared with the effects the chain recorded (status, '
  + 'the four gas components, the events digest and the Lamport version); one that does not '
  + 'match is published as divergent, never as a trace of the chain, and one that cannot be '
  + 'traced is refused with its reason. The source shown is the bytecode disassembly of the '
  + 'packages that ran, read from chain state';
