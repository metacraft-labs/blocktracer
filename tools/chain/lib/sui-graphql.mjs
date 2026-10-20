// sui-graphql.mjs — the Sui acquisition reads, over Sui's GraphQL service.
//
// ── WHY GRAPHQL AND NOTHING ELSE ──────────────────────────────────────────────────────
//
// Chain-Data-Ingestion.md §4.6: Sui's JSON-RPC was disabled on public fullnodes in July
// 2026, "build the Sui adapter on GraphQL from the first commit". So every read this
// producer family makes — checkpoints, transactions, effects, and the epoch's protocol
// version — goes through one GraphQL endpoint, and so does the replay itself:
// `sui replay --node <network|url>` (crate `sui-replay-2`) fetches the transaction and
// the exact object versions it names from the same service
// (https://github.com/MystenLabs/sui/blob/main/crates/sui-data-store/src/node.rs).
//
// ── WHAT A CHECKPOINT READ RETURNS, AND WHY IT IS KEPT VERBATIM ───────────────────────
//
// `checkpointWithTransactions` returns the checkpoint header plus every transaction in
// it, in checkpoint order, each with its effects as the service published them
// (`effectsJson`) and its body (`transactionJson`). The producer derives rows from these
// and writes the reads themselves into the capture (`acquisition.json`), so a tree's rows
// can be re-derived from what was read without asking the network again.
//
// The service pages a checkpoint's transactions; `maxPageSize` for
// `Checkpoint.transactions` was 50 on 2026-10-20 (`serviceConfig.maxPageSize`), and the
// page loop below follows `pageInfo` rather than assuming one page suffices.

/** Named networks, as `sui replay --node` spells them, and their GraphQL services. */
export const GRAPHQL_URLS = Object.freeze({
  mainnet: 'https://graphql.mainnet.sui.io/graphql',
  testnet: 'https://graphql.testnet.sui.io/graphql',
  devnet: 'https://graphql.devnet.sui.io/graphql',
});

/** The GraphQL URL a `--node` value names: a known network, or the value itself. */
export function graphqlUrlFor(node) {
  if (Object.hasOwn(GRAPHQL_URLS, node)) return GRAPHQL_URLS[node];
  if (/^https?:\/\//.test(node)) return node;
  throw new Error(`--node '${node}' is neither a known network (${Object.keys(GRAPHQL_URLS)
    .join(', ')}) nor an http(s) GraphQL URL`);
}

/** A GraphQL answer that carried `errors`, kept apart from transport failures. */
export class GraphqlError extends Error {
  constructor(errors) {
    super(`GraphQL errors: ${JSON.stringify(errors).slice(0, 600)}`);
    this.errors = errors;
  }
}

/**
 * POST one query. Transport failures and 5xx/429 answers are retried with backoff; a
 * GraphQL `errors` answer is not, because it is a statement about the query, and is
 * thrown as `GraphqlError` so a caller can tell it from an outage.
 */
export async function graphql(url, query, variables = {},
                              { retries = 4, fetchImpl = fetch, timeoutMs = 60_000 } = {}) {
  let lastError;
  for (let attempt = 0; attempt <= retries; attempt++) {
    if (attempt > 0) await new Promise((r) => setTimeout(r, 500 * 2 ** (attempt - 1)));
    let res;
    try {
      res = await fetchImpl(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ query, variables }),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (e) {
      lastError = e;
      continue;
    }
    if (res.status === 429 || res.status >= 500) {
      lastError = new Error(`HTTP ${res.status} from ${url}`);
      continue;
    }
    const body = await res.json();
    if (body.errors?.length) throw new GraphqlError(body.errors);
    if (!res.ok) throw new Error(`HTTP ${res.status} from ${url}: ${JSON.stringify(body)}`);
    return body.data;
  }
  throw new Error(`${url} did not answer after ${retries + 1} attempts: ${lastError?.message}`);
}

const CHECKPOINT_QUERY = `
query($seq: UInt53!, $after: String) {
  checkpoint(sequenceNumber: $seq) {
    sequenceNumber digest previousCheckpointDigest timestamp networkTotalTransactions
    epoch { epochId protocolConfigs { protocolVersion } }
    transactions(first: 50, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        digest
        kind { __typename }
        sender { address }
        gasInput { gasSponsor { address } gasPrice gasBudget }
        effects {
          status lamportVersion
          executionError { message abortCode }
          gasEffects { gasSummary { computationCost storageCost storageRebate nonRefundableStorageFee } }
          effectsJson
        }
        transactionJson
      }
    }
  }
}`;

/**
 * Read checkpoint `seq` and every transaction in it, in checkpoint order. Returns null
 * when the service answers that the checkpoint does not exist (yet).
 */
export async function checkpointWithTransactions(url, seq, opts = {}) {
  let header = null;
  const transactions = [];
  let after = null;
  for (;;) {
    const data = await graphql(url, CHECKPOINT_QUERY, { seq, after }, opts);
    const cp = data.checkpoint;
    if (cp === null) return null;
    header ??= {
      sequenceNumber: cp.sequenceNumber,
      digest: cp.digest,
      previousCheckpointDigest: cp.previousCheckpointDigest,
      timestamp: cp.timestamp,
      networkTotalTransactions: cp.networkTotalTransactions,
      epoch: cp.epoch.epochId,
      protocolVersion: cp.epoch.protocolConfigs.protocolVersion,
    };
    for (const n of cp.transactions.nodes) {
      transactions.push({
        digest: n.digest,
        kind: n.kind.__typename,
        sender: n.sender?.address ?? null,
        gasSponsor: n.gasInput?.gasSponsor?.address ?? null,
        gasPrice: n.gasInput?.gasPrice ?? null,
        gasBudget: n.gasInput?.gasBudget ?? null,
        status: n.effects.status,
        lamportVersion: n.effects.lamportVersion,
        executionError: n.effects.executionError,
        gasSummary: n.effects.gasEffects?.gasSummary ?? null,
        effectsJson: n.effects.effectsJson,
        transactionJson: n.transactionJson,
      });
    }
    if (!cp.transactions.pageInfo.hasNextPage) break;
    after = cp.transactions.pageInfo.endCursor;
  }
  return { ...header, transactions };
}

/** The newest checkpoint the service has, and its timestamp. */
export async function latestCheckpoint(url, opts = {}) {
  const data = await graphql(url, '{ checkpoint { sequenceNumber timestamp } }', {}, opts);
  return data.checkpoint;
}

/** The protocol version of `epoch`, and that epoch's first checkpoint. */
export async function epochFacts(url, epoch, opts = {}) {
  const data = await graphql(url, `query($e: UInt53!) { epoch(epochId: $e) {
      epochId protocolConfigs { protocolVersion }
      checkpoints(first: 1) { nodes { sequenceNumber timestamp } } } }`, { e: epoch }, opts);
  const e = data.epoch;
  if (e === null) return null;
  return {
    epoch: e.epochId,
    protocolVersion: e.protocolConfigs.protocolVersion,
    firstCheckpoint: e.checkpoints.nodes[0]?.sequenceNumber ?? null,
    firstCheckpointTimestamp: e.checkpoints.nodes[0]?.timestamp ?? null,
  };
}

/**
 * The first epoch whose protocol version is at least `minProtocol`, found by binary search
 * over epochs `[0, currentEpoch]`. Protocol versions never decrease from one epoch to the
 * next, which is what makes the search sound; a non-monotone answer is reported rather than
 * searched through.
 */
export async function firstEpochAtProtocol(url, minProtocol, currentEpoch, opts = {}) {
  const pv = async (e) => {
    const f = await epochFacts(url, e, opts);
    if (f === null) throw new Error(`epoch ${e} is not served by ${url}`);
    return f;
  };
  let lo = 0;
  let hi = currentEpoch;
  if ((await pv(hi)).protocolVersion < minProtocol) return null;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if ((await pv(mid)).protocolVersion >= minProtocol) hi = mid;
    else lo = mid + 1;
  }
  const found = await pv(lo);
  const before = lo > 0 ? await pv(lo - 1) : null;
  if (before !== null && before.protocolVersion >= minProtocol) {
    throw new Error(`protocol versions are not monotone around epoch ${lo}`);
  }
  return { ...found, previousProtocolVersion: before?.protocolVersion ?? null };
}

/**
 * The input object versions a transaction consumed, as its effects record them:
 * objects it changed (at the version it read), consensus objects it only read, and
 * objects loaded at runtime (dynamic fields). This is the whole of a version-addressed
 * prestate — Chain-Support-Matrix.md §1.4 — and nothing else is read to replay it.
 */
export function inputVersionsOf(effectsJson) {
  const out = [];
  for (const o of effectsJson?.changedObjects ?? []) {
    if (o.inputState === 'INPUT_OBJECT_STATE_EXISTS') {
      out.push({ objectId: o.objectId, version: o.inputVersion, read: 'changed' });
    }
  }
  for (const o of effectsJson?.unchangedConsensusObjects ?? []) {
    if (o.version !== undefined) {
      out.push({ objectId: o.objectId, version: o.version, read: 'consensus-read-only' });
    }
  }
  for (const o of effectsJson?.unchangedLoadedRuntimeObjects ?? []) {
    out.push({ objectId: o.objectId, version: o.version, read: 'runtime-loaded' });
  }
  return out;
}
