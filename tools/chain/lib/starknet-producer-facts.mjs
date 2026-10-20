// starknet-producer-facts.mjs — the facts the Starknet mainnet producer states about its
// capture.
//
// The Starknet twin of `eth-producer-facts.mjs` and `sui-producer-facts.mjs`, and
// deliberately a DUPLICATE of their shape rather than an instance of a shared seam: ING-7's
// two-consumer rule (Chain-Delivery DEL-7) forbids extracting one until the producers it
// would serve have shipped without it. Everything here is something the snapshot carries
// as DATA (Data-Contract.md §5.3) that a reader must not assume; the producer imports it
// rather than spelling it, which `lib/producer-scan.mjs` R1–R4 checks.
//
// ── WHAT DIFFERS FROM THE OTHER CHAINS, MEMBER BY MEMBER ──────────────────────────────
//
//   * THE RECORDER IS STARKWARE'S OWN EXECUTOR. `codetracer-cairo-recorder`'s `onchain/`
//     re-runs each block in blockifier (the sequencer's transaction executor, over
//     cairo-vm) and records cairo-vm's own trace — one step per executed CASM instruction,
//     across every entry point the transaction ran. Chain-Support-Matrix.md §2.1's
//     "Real VM" row, where §2.2 still says "Hybrid, VM trace not routed".
//   * THE COST VECTOR HAS THREE DIMENSIONS — L1 gas, L1 data gas and L2 gas — each with
//     the sender's own bound (`resource_bounds.*.max_amount` and `max_price_per_unit` on a
//     v3 transaction) and the block's price, and one FEE that the receipt states in its
//     own unit (FRI for STRK-paid, WEI for ETH-paid). This is the "resource bounds across
//     several dimensions rather than one gas number" Recorder-Cairo CXP-CAIRO-3 names.
//   * THE ROLES ARE NOT ONE ADDRESS. An INVOKE or DECLARE is sent by an ACCOUNT CONTRACT
//     (`sender_address`), which is also the fee payer; a DEPLOY_ACCOUNT's sender is the
//     account it creates; an L1_HANDLER has NO ordinary sender at all — it is initiated by
//     an L1 message — so it states no role rather than inventing one (CXP-CAIRO-4's
//     `test_an_l1_initiated_transaction_has_a_role_that_fits`).
//   * POSITIONS ARE CASM, NOT CAIRO. A declared class carries its Sierra program and ABI
//     and no debug info mapping a pc to a Cairo source line, so the recorder positions
//     every step in a listing of the CASM the VM ran (`cairo-casm`). Source level is
//     CXP-CAIRO-4's: verified sources, validated by class hash.

/** `provenance.chain` — the slug the published tree is keyed by. Slugs never change. */
export const CHAIN_SLUG = 'starknet-mainnet';

/**
 * `provenance.recorder` — `codetracer-cairo-onchain`, writing through the same Nim trace
 * writer as the EVM and Move recorders, so the container version is 5 (header byte 6).
 * The producer reads that byte and refuses a container that disagrees.
 */
export const RECORDER = Object.freeze({ id: 'starknet-cairo', traceSchema: 'ctfs/v5' });

/**
 * `provenance.prestateStrategy` — Chain-Support-Matrix.md §1.4. The recorder pins the
 * PARENT block's state (read from the node, prefetched as one
 * `starknet_simulateTransactions` + `RETURN_INITIAL_READS` call) and re-executes the
 * block's indices 0..k-1 before k, so the state transaction k runs on is the one the
 * sequencer gave it — and the block's whole state diff is compared with the node's.
 */
export const PRESTATE_STRATEGY = 'replay-preceding';

/**
 * `provenance.identifierEncoding`. Every Starknet identifier is a felt written as `0x` +
 * 1-63 hex — Search-And-Routing.md §2's felt row — which `hex` already covers, including
 * the shard rule for a short one (`contract/shards.nim` pads it to four characters). The
 * node answers them lowercase and without leading zeros, which is the spelling published.
 */
export const IDENTIFIER_ENCODING = Object.freeze({
  transaction: 'hex',
  block: 'hex',
  address: 'hex',
});

/** A source bundle's `language` — positions are lines of a CASM listing. */
export const POSITION_LANGUAGE = 'cairo-casm';

/** A position stream's own `schema` token, republished verbatim by the reader. */
export const POSITION_STREAM_SCHEMA = 'cairo-casm-positions/1';

/** The instruction listing's own `schema` token. */
export const INSTRUCTION_STREAM_SCHEMA = 'cairo-casm-instructions/1';

/** The call-trace stream's own `schema` token. */
export const CALLTRACE_STREAM_SCHEMA = 'cairo-call-frames/1';

/**
 * `sidecar:instructions.isa` — the instruction set the listing's mnemonics belong to.
 * `cairo` names the Cairo VM's instruction encoding, which Cairo 0 programs and compiled
 * Cairo 1 (CASM) share; it is the same on every chain that runs the Cairo VM, so it names
 * no chain.
 */
export const INSTRUCTION_SET = 'cairo';

/**
 * `transactions[].executions` — one entry, `transaction`: a Starknet transaction is one
 * account-mediated execution (validate, execute, fee transfer — all recorded in the one
 * container), with no public/private split for a selector to name. A row this producer did
 * not trace states the reason on its single entry.
 */
export const executionsForRow = (reason) => (reason
  ? [{ selector: 'transaction', reason }]
  : [{ selector: 'transaction' }]);

const DIMENSIONS = Object.freeze([
  ['l1Gas', 'l1_gas', 'l1_gas_price'],
  ['l1DataGas', 'l1_data_gas', 'l1_data_gas_price'],
  ['l2Gas', 'l2_gas', 'l2_gas_price'],
]);

/**
 * `transactions[].cost` — one entry per resource dimension the receipt reports, plus the
 * fee.
 *
 * `used` is the receipt's `execution_resources.<dim>`. `limit` is the sender's
 * `resource_bounds.<DIM>.max_amount` on a v3 transaction and empty on an older one, which
 * bounded the FEE (`max_fee`) and no dimension. `price` is the block's price for that
 * dimension in the fee's own unit — FRI when the fee is paid in STRK, WEI when in ETH —
 * read from the header the transaction settled in.
 *
 * THE FEE IS ITS OWN ENTRY, `fee`, with the receipt's `actual_fee.amount` and its `unit`
 * verbatim, because it is the figure the account was charged and it is not the product of
 * any one dimension. Its `limit` is the v1 `max_fee` where there is one.
 *
 * `refundable: false` on all of them: Starknet charges what was used, it does not charge
 * a bound and refund the rest.
 *
 * An absent figure is an empty string, because `used` is required.
 */
export const costVectorForRow = ({ body, receipt, header } = {}) => {
  const unit = receipt?.actual_fee?.unit ?? '';
  const token = unit === 'FRI' ? 'STRK' : unit === 'WEI' ? 'ETH' : '';
  const priceKey = unit === 'WEI' ? 'price_in_wei' : 'price_in_fri';
  const bounds = body?.resource_bounds ?? null;
  const v = [];
  for (const [name, key, priceMember] of DIMENSIONS) {
    const used = receipt?.execution_resources?.[key];
    if (used === undefined || used === null) continue;
    const b = bounds?.[key] ?? bounds?.[key.toUpperCase()] ?? null;
    v.push({
      name,
      used: String(used),
      limit: b?.max_amount ?? '',
      price: header?.[priceMember]?.[priceKey] ?? '',
      unit: 'gas',
      token,
      refundable: false,
    });
  }
  v.push({
    name: 'fee',
    used: receipt?.actual_fee?.amount ?? '',
    limit: body?.max_fee ?? '',
    price: '',
    unit,
    token,
    refundable: false,
  });
  return v;
};

/**
 * `transactions[].roles` — who acted, and only the roles the transaction type has.
 *
 * INVOKE and DECLARE are sent by an account contract (`sender_address`), which pays the
 * fee as well: one address, two roles, both stated, because a chain with a paymaster or a
 * sponsored fee would state two different ones and the two must not be collapsed by the
 * reader. DEPLOY_ACCOUNT's sender is the account being deployed (`contract_address` on
 * the receipt) and it pays for its own deployment. L1_HANDLER has no ordinary sender — it
 * is initiated by a message from L1, whose sender is an L1 address and not a Starknet
 * account — so it states NO role, and the explorer's `From` cell keeps its honest dash.
 */
export const rolesForRow = ({ body, receipt } = {}) => {
  const type = body?.type ?? '';
  if (type === 'INVOKE' || type === 'DECLARE') {
    const a = body?.sender_address;
    return a ? [{ role: 'sender', address: a }, { role: 'feePayer', address: a }] : [];
  }
  if (type === 'DEPLOY_ACCOUNT') {
    const a = receipt?.contract_address;
    return a ? [{ role: 'sender', address: a }, { role: 'feePayer', address: a }] : [];
  }
  return [];
};

/**
 * `transactions[].payload` — what was called.
 *
 * An account's `__execute__` takes a list of calls. In the Cairo 1 account convention the
 * calldata is `[n_calls, (to, selector, len, ...data) x n_calls]`, and the FIRST call's
 * `to` and `selector` are what the explorer's `To / target` and `Method` columns are of.
 * They are published as the felts they are, not resolved to a name: resolving needs the
 * target class's ABI, which the snapshot's sources carry for the classes that ran and the
 * reader can join. A calldata that does not decode under that convention (a legacy
 * account, or one call too short to read) states NEITHER rather than a guess.
 *
 * An L1_HANDLER calls `entry_point_selector` on `contract_address` directly; a
 * DEPLOY_ACCOUNT or DECLARE calls no method a column could name.
 *
 * `raw` is empty for the reason `eth-producer-facts.mjs` measured: the transaction page
 * prints it in one row that does not fold.
 */
export const payloadForRow = ({ body } = {}) => {
  const type = body?.type ?? '';
  if (type === 'L1_HANDLER') {
    return { raw: '', selector: body?.entry_point_selector ?? '',
             target: body?.contract_address ?? '' };
  }
  if (type !== 'INVOKE') return { raw: '', selector: '', target: '' };
  const cd = Array.isArray(body?.calldata) ? body.calldata : [];
  const n = cd.length > 0 ? Number.parseInt(cd[0], 16) : Number.NaN;
  if (!Number.isInteger(n) || n < 1 || cd.length < 4) return { raw: '', selector: '', target: '' };
  const len = Number.parseInt(cd[3], 16);
  if (!Number.isInteger(len) || 4 + len > cd.length) return { raw: '', selector: '', target: '' };
  return { raw: '', selector: cd[2], target: cd[1] };
};
