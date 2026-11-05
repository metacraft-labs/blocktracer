// aptos-producer-facts.mjs — the facts an Aptos producer states about its capture.
//
// The Aptos twin of `sui-producer-facts.mjs`, and deliberately a DUPLICATE of its shape
// rather than an instance of a shared seam: ING-7's two-consumer rule (Chain-Delivery
// DEL-7) forbids extracting the seam until the producers have shipped without it. Every
// fact here is something the snapshot carries as DATA (Data-Contract.md §5.3) that a reader
// must not assume; the producer imports it rather than spelling it, which
// `lib/producer-scan.mjs` R1–R4 checks.

/**
 * `provenance.chain`. Aptos is not in Chain-Support-Matrix.md §4's launch set, so no slug
 * was assigned there; this one names the network, as `starknet-mainnet` does, because
 * Aptos runs a mainnet and a testnet under the same VM and a bare `aptos` would have to
 * be renamed the day the testnet is captured. Slugs never change.
 */
export const CHAIN_SLUG = 'aptos-mainnet';

/**
 * `provenance.recorder` — `codetracer-move-recorder aptos-replay`, converting the value
 * trace `aptos move replay --trace` writes (metacraft-labs/aptos-core, branch
 * `codetracer/value-tracing`) into a CTFS container through the same converter as Sui.
 */
export const RECORDER = Object.freeze({ id: 'aptos-move', traceSchema: 'ctfs/v5' });

/**
 * `provenance.prestateStrategy` — Chain-Support-Matrix.md §1.4. `aptos move replay` reads
 * every state value the transaction touches at ledger version V−1 over REST, and the
 * recorder reads each entered module at V−1 the same way; nothing before the transaction is
 * re-executed to obtain it.
 */
export const PRESTATE_STRATEGY = 'version-addressed';

/**
 * `provenance.ordering` — Static-Site-Architecture.md §2.3: an Aptos transaction is
 * sequenced by its ledger VERSION, which numbers transactions across blocks. Every row
 * states it as a decimal string (S5-VERSION-STATED); `blocks[]` stays block heights.
 */
export const ORDERING = 'globalVersion';

/**
 * `provenance.identifierEncoding` — per KIND. A transaction hash, a block hash and an
 * account address are all `0x` + 64 lowercase hex on the REST API, so all three are hex.
 */
export const IDENTIFIER_ENCODING = Object.freeze({
  transaction: 'hex',
  block: 'hex',
  address: 'hex',
});

/** A source bundle's `language` — positions are lines of a Move bytecode disassembly. */
export const POSITION_LANGUAGE = 'move-disassembly';

/** A position stream's own `schema` token, republished verbatim by the reader. */
export const POSITION_STREAM_SCHEMA = 'move-disassembly-positions/1';

/** The call-trace stream's own `schema` token. */
export const CALLTRACE_STREAM_SCHEMA = 'move-call-frames/1';

/**
 * The executable format an Aptos program is executed from, declared as `provenance.vm`:
 * Aptos's DIALECT of Move bytecode, the registered sibling of `sui-move` (Configuration.md
 * §2.1's dialect rule; `flow-producer-facts-selftest.mjs` FORMAT_DIALECTS). The two
 * dialects differ in file-format versions and instructions (Aptos has enums, closures and
 * signed integers), so one table selected by a bare `move` could be wrong for one of them.
 */
export const INSTRUCTION_SET = 'aptos-move';

/**
 * What the chain IS, declared as `provenance.identity` and carried onto the registry row
 * (Configuration.md §2.1; Data-Contract.md §5.3, S5-IDENTITY-DECLARED).
 *
 *   caip2          `aptos:1` — the ChainAgnostic `aptos` namespace (aptos/caip2.md, Draft,
 *                  2025-12-12) names a chain by its numeric `chain_id`, and mainnet's is 1;
 *                  `GET /v1` on the mainnet fullnode answers `"chain_id": 1`.
 *   nativeCurrency APT, 8 decimals (1 APT = 10^8 octas).
 *   blockTimeMs    the nominal block cadence, MEASURED on mainnet 2026-11-03 over REST
 *                  `/v1/blocks/by_height/{h}` `block_timestamp` (µs): 100,000 blocks before
 *                  1,158,421,321 took 3,696.6 s (36.97 ms), 1,000,000 took 36,886.8 s
 *                  (36.89 ms) and 10,000,000 took 375,194.5 s (37.52 ms). A nominal figure,
 *                  not a per-window one.
 *   finality       `instant` (tools/chain/finality-rules.json): a block is committed by a
 *                  BFT quorum certificate and is never reorganised.
 */
export const IDENTITY = Object.freeze({
  caip2: 'aptos:1',
  name: 'Aptos Mainnet',
  family: 'move',
  nativeCurrency: Object.freeze({ symbol: 'APT', decimals: 8 }),
  blockTimeMs: 37,
  finality: Object.freeze({ rule: 'instant' }),
});

/**
 * The transaction types the REST API publishes that are not a user's: the protocol runs
 * them in every block (a prologue, an epilogue or checkpoint, and validator transactions
 * such as DKG and JWK updates). They are listed in `blocks[].systemTransactions`
 * (Data-Contract.md §5.2, S5-SYSTEM-TRANSACTIONS) rather than published as rows: nobody
 * sent them, they cost nothing, and a row would put them in every denominator.
 */
export const SYSTEM_TRANSACTION_TYPES = Object.freeze([
  'block_metadata_transaction', 'block_epilogue_transaction',
  'state_checkpoint_transaction', 'validator_transaction', 'genesis_transaction',
]);

/** Whether a REST transaction is a user's, i.e. a row. */
export const isUserTransaction = (tx) => tx?.type === 'user_transaction';

// DEL-7: the shared one-execution helper, exported under this module's contract name.
export { oneExecutionPerTransaction as executionsForRow } from './producer-runtime.mjs';

/** The storage refund the chain's own `FeeStatement` event states, in octas, or null. */
export const storageRefundOf = (tx) => {
  const ev = (tx?.events ?? []).find((e) => e?.type === '0x1::transaction_fee::FeeStatement');
  const r = ev?.data?.storage_fee_refund_octas;
  return r === undefined || r === null ? null : String(r);
};

/**
 * `cost[]` — what the sender paid is `gas_used × gas_unit_price` octas, and it is
 * published as that product rather than as two numbers the reader multiplies (§5.3: the
 * reader supplies no arithmetic). The limit is the sender's `max_gas_amount` at that
 * price. Storage deposits refunded to the payer are their own negative-signed entry, as
 * Sui's rebate is, read off the chain's `FeeStatement` event.
 */
export const costVectorForRow = (tx) => {
  const used = BigInt(tx?.gas_used ?? 0);
  const price = BigInt(tx?.gas_unit_price ?? 0);
  const max = BigInt(tx?.max_gas_amount ?? 0);
  const refund = storageRefundOf(tx);
  return [
    { name: 'gas', used: String(used * price), limit: String(max * price), price: String(price),
      unit: 'octa', token: 'APT', refundable: false },
    { name: 'storageFeeRefund',
      used: refund === null || refund === '0' ? '0' : `-${refund}`,
      unit: 'octa', token: 'APT', refundable: false },
  ];
};

/**
 * `roles[]` — the sender always; a fee payer when the transaction was sponsored
 * (`fee_payer_signature`), as a `sponsor` and the `feePayer`; otherwise the sender pays.
 */
export const rolesForRow = (tx) => {
  const roles = [];
  const sender = typeof tx?.sender === 'string' ? tx.sender : null;
  const sig = tx?.signature;
  const sponsor = sig?.type === 'fee_payer_signature' ? sig.fee_payer_address ?? null : null;
  if (sender) roles.push({ role: 'sender', address: sender });
  if (sponsor && sponsor !== sender && !/^0x0*$/.test(sponsor)) {
    roles.push({ role: 'sponsor', address: sponsor });
    roles.push({ role: 'feePayer', address: sponsor });
  } else if (sender) {
    roles.push({ role: 'feePayer', address: sender });
  }
  return roles;
};

/**
 * `payload` — what the transaction asked for. An entry-function call's selector is its
 * `<address>::<module>::<function>` and its target is the module's address; a script or
 * any other payload kind names itself.
 */
export const payloadForRow = (tx) => {
  const p = tx?.payload ?? {};
  if (p.type === 'entry_function_payload' && typeof p.function === 'string') {
    return { raw: '', selector: p.function, target: p.function.split('::')[0] };
  }
  if (p.type === 'multisig_payload' && typeof p.transaction_payload?.function === 'string') {
    const f = p.transaction_payload.function;
    return { raw: '', selector: f, target: f.split('::')[0] };
  }
  return { raw: '', selector: p.type ?? '', target: '' };
};

/**
 * `provenance.reachReason` — why history starts at `replayableFrom`. MEASURED 2026-11-03:
 * the public mainnet fullnode PRUNES. Its ledger info states `oldest_ledger_version` and
 * `oldest_block_height`, a read below them answers HTTP 410 `version_pruned`, and both
 * move up with the chain (~150 M versions, ~25.7 M blocks, about eleven days, retained).
 * Chain-Support-Matrix.md §1.3's table says Aptos history reaches genesis; that is true of
 * an archive node and not of the endpoint this capture read.
 */
export const reachReasonFor = (oldestBlock, oldestVersion) =>
  `the REST endpoint this capture read prunes: when measured it served blocks from height `
  + `${oldestBlock} and ledger versions from ${oldestVersion} upward, and answered `
  + '`410 version_pruned` below them. A transaction is replayed from the state at the '
  + 'version before it, read over that endpoint, so one below the boundary cannot be '
  + 'replayed from it; the boundary moves up as the node prunes. An archive node would '
  + 'serve history to genesis';

/** `provenance.verification` — what each trace is compared against, and the refusal. */
export const VERIFICATION = 'each transaction is re-executed by `aptos move replay` from the '
  + 'state at the version before it and compared with the transaction info the chain '
  + 'committed (status, gas used, the write-set hash and the event root hash); one that '
  + 'does not match is published as divergent, never as a trace of the chain, and one that '
  + 'cannot be traced is refused with its reason. The source shown is the bytecode '
  + 'disassembly of the modules that ran, read from chain state at that version';

/** The four facts `aptos move replay` compares (`ensure_match_transaction_info`), in order. */
export const COMPARED_FACTS = Object.freeze(['status', 'gasUsed', 'writeSetHash', 'eventRootHash']);

/**
 * The comparison's result, from what the replay reported. The CLI stops at the FIRST fact
 * that differs and names it with both readings (`TransactionOutput does not match
 * TransactionInfo: version:V, <fact>:<replayed>, expected:<published>`); the facts after it
 * were not compared, and are reported as such rather than as matched. A clean replay
 * matched all four. `published` is the chain's own reading from the REST transaction.
 */
export function effectsFromReplay(tx, mismatchLine) {
  const published = {
    status: tx?.vm_status ?? null,
    gasUsed: tx?.gas_used === undefined ? null : String(tx.gas_used),
    writeSetHash: tx?.state_change_hash ?? null,
    eventRootHash: tx?.event_root_hash ?? null,
  };
  if (!mismatchLine) {
    return { reproduced: true, matched: COMPARED_FACTS.length, mismatched: 0, mismatches: [],
             comparedBy: 'aptos move replay', compared: [...COMPARED_FACTS] };
  }
  const fields = { status: 'status', gas_used: 'gasUsed', write_set_hash: 'writeSetHash',
                   event_root_hash: 'eventRootHash' };
  const m = /version:\d+, (status|gas_used|write_set_hash|event_root_hash):(.*?), (?:auxiliary data:.*?, )?expected:(.*?)(?:, |$)/
    .exec(mismatchLine);
  const field = m ? fields[m[1]] : null;
  const at = field === null ? 0 : COMPARED_FACTS.indexOf(field);
  return {
    reproduced: false,
    matched: at,
    mismatched: 1,
    mismatches: [{ field: field ?? 'unparsed', published: field ? published[field] : null,
                   replayed: m ? m[2].trim() : mismatchLine.slice(0, 300), matches: false }],
    comparedBy: 'aptos move replay',
    compared: COMPARED_FACTS.slice(0, at + 1),
  };
}
