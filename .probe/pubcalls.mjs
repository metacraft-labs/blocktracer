// A body is not automatically something to trace. Aztec's private half is
// never published; only ENQUEUED PUBLIC CALLS re-execute in the AVM. So ask,
// over both outcome classes, how many of these transactions have any public
// call at all — that is the ceiling on what a historic trace could ever show.
import { readFileSync } from 'node:fs';
import { Tx } from '@aztec/stdlib/tx';
import { BarretenbergSync } from '@aztec/bb.js';
await BarretenbergSync.initSingleton();

const BASE = 'https://aztec-labs-snapshots.com/testnet/txs';
const PATH = 'aztec-11155111-1821665230-0xd73a91bdcf6891c7642f3e460036e1ef2cc23178';
const snap = JSON.parse(readFileSync('client/fixtures/chain/aztec-testnet/snapshot.json', 'utf8'));

const pick = (outcome, n) => snap.transactions.filter((t) => t.outcome === outcome).slice(0, n);
const groups = {
  replayed: pick('replayed', 24),
  divergent: pick('divergent', 5),
  pruned: snap.transactions.filter((t) => t.outcome === 'pruned')
    .filter((_, i) => i % 25 === 0).slice(0, 34),
};

for (const [name, list] of Object.entries(groups)) {
  let withPublic = 0, decoded = 0, absent = 0; const counts = {};
  for (const t of list) {
    const r = await fetch(`${BASE}/${PATH}/txs/${t.txHash}.bin`);
    if (!r.ok) { absent++; continue; }
    const buf = Buffer.from(await r.arrayBuffer());
    let tx; try { tx = Tx.fromBuffer(buf); } catch { continue; }
    decoded++;
    const n = (typeof tx.getPublicCallRequests === 'function' ? tx.getPublicCallRequests() : []).length;
    counts[n] = (counts[n] ?? 0) + 1;
    if (n > 0) withPublic++;
  }
  console.log(`${name.padEnd(10)} sampled=${String(list.length).padEnd(3)} decoded=${decoded} absent=${absent} `
    + `withPublicCalls=${withPublic}  distribution(callRequests->txs)=${JSON.stringify(counts)}`);
}
