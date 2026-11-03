// aptos-rest.mjs — the few Aptos REST reads a capture makes, and nothing else.
//
// The Aptos twin of `sui-graphql.mjs`. Every read is a GET on the node's `/v1` API
// (Chain-Data-Ingestion.md §1), answered in JSON; the node is a URL or a network name.

/** The REST base (`…`, without `/v1`) of a network name or URL. */
export function restBaseFor(node) {
  if (['mainnet', 'testnet', 'devnet'].includes(node)) {
    return `https://fullnode.${node}.aptoslabs.com`;
  }
  return String(node).replace(/\/+$/, '').replace(/\/v1$/, '');
}

/** GET `<base>/v1<path>` as JSON; a non-200 is an error naming the path and the answer. */
export async function restGet(base, path, { fetchImpl = fetch, retries = 6 } = {}) {
  for (let attempt = 0; ; attempt++) {
    const res = await fetchImpl(`${base}/v1${path}`, { headers: { accept: 'application/json' } });
    const text = await res.text();
    if (res.status === 200) return JSON.parse(text);
    if ((res.status === 429 || res.status >= 500) && res.status !== 599 && attempt < retries) {
      await new Promise((ok) => setTimeout(ok, res.status === 429 ? 30_000 : 3_000));
      continue;
    }
    throw new Error(`GET ${base}/v1${path} answered ${res.status}: ${text.slice(0, 300)}`);
  }
}

/** The ledger info: tip and the node's retention boundary, as integers where they fit. */
export async function ledgerInfo(base, opts) {
  const l = await restGet(base, '', opts);
  return {
    chainId: l.chain_id,
    ledgerVersion: l.ledger_version,
    oldestLedgerVersion: l.oldest_ledger_version,
    blockHeight: Number(l.block_height),
    oldestBlockHeight: Number(l.oldest_block_height),
    ledgerTimestampUs: l.ledger_timestamp,
    nodeRole: l.node_role ?? null,
    gitHash: l.git_hash ?? null,
  };
}

/**
 * A block with EVERY transaction in it. `/blocks/by_height/{h}?with_transactions=true`
 * answers at most one page of transactions, so a block holding more is completed from
 * `/transactions?start=&limit=` until its `last_version` is reached; a block whose
 * transactions do not run first..last without a gap is refused.
 */
export async function blockWithTransactions(base, height, opts) {
  const b = await restGet(base, `/blocks/by_height/${height}?with_transactions=true`, opts);
  const first = BigInt(b.first_version);
  const last = BigInt(b.last_version);
  const txs = [...(b.transactions ?? [])];
  while (BigInt(txs.length) < last - first + 1n) {
    const start = first + BigInt(txs.length);
    const limit = Math.min(100, Number(last - start + 1n));
    const page = await restGet(base, `/transactions?start=${start}&limit=${limit}`, opts);
    if (!Array.isArray(page) || page.length === 0) {
      throw new Error(`block ${height}: /transactions?start=${start} returned nothing`);
    }
    txs.push(...page);
  }
  txs.forEach((t, i) => {
    if (BigInt(t.version) !== first + BigInt(i)) {
      throw new Error(`block ${height}: transaction ${i} is version ${t.version}, not ${first + BigInt(i)}`);
    }
  });
  return { ...b, transactions: txs };
}

/** A block's header alone (no transactions): its hash, versions and timestamp. */
export async function blockHeader(base, height, opts) {
  return restGet(base, `/blocks/by_height/${height}?with_transactions=false`, opts);
}

/**
 * The recorder's reproducible recording id, computed here because `aptos-replay` takes a
 * UUID and has no `derive` of its own: a UUIDv7 (RFC 9562 §5.7) whose 48-bit timestamp is
 * `timeMs` (the block's timestamp) and whose remaining bits come from the SHA-256 of `key`
 * (the transaction hash). The same layout `codetracer-move-recorder replay
 * --recording-id derive` uses for Sui (`replay::derived_recording_id`), so the container's
 * only per-run bytes become a function of the transaction.
 */
export async function derivedRecordingId(timeMs, key) {
  const { createHash } = await import('node:crypto');
  const h = createHash('sha256').update(String(key)).digest();
  const ms = BigInt(timeMs) & 0xFFFFFFFFFFFFn;
  const b = Buffer.alloc(16);
  for (let i = 0; i < 6; i++) b[i] = Number((ms >> BigInt(8 * (5 - i))) & 0xFFn);
  b[6] = 0x70 | (h[0] & 0x0f);
  b[7] = h[1];
  b[8] = 0x80 | (h[2] & 0x3f);
  h.copy(b, 9, 3, 10);
  const x = b.toString('hex');
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}
