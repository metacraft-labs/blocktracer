// Is a body from the public store actually a replay-grade `Tx`, or just bytes
// that happen to begin with the right hash? Deserialise several and ask the
// same module the replay path uses (`@aztec/stdlib/tx`), then recompute the
// hash from the decoded object rather than reading the leading bytes back.
import { readFileSync } from 'node:fs';
import { Tx } from '@aztec/stdlib/tx';
import { BarretenbergSync } from '@aztec/bb.js';
await BarretenbergSync.initSingleton();

const BASE = 'https://aztec-labs-snapshots.com/testnet/txs';
const PATH = 'aztec-11155111-1821665230-0xd73a91bdcf6891c7642f3e460036e1ef2cc23178';

const snap = JSON.parse(readFileSync('client/fixtures/chain/aztec-testnet/snapshot.json', 'utf8'));
const sample = snap.transactions.slice().sort((a, b) => a.blockNumber - b.blockNumber)
  .filter((_, i) => i % 200 === 0).slice(0, 5);

let ok = 0;
for (const t of sample) {
  const r = await fetch(`${BASE}/${PATH}/txs/${t.txHash}.bin`);
  const buf = Buffer.from(await r.arrayBuffer());
  let tx, err = null;
  try { tx = Tx.fromBuffer(buf); } catch (e) { err = e.message; }
  if (err) { console.log(`blk ${t.blockNumber}: DECODE FAILED: ${String(err).slice(0, 110)}`); continue; }
  let hash = '(n/a)', matches = false;
  try { hash = (await tx.getTxHash()).toString(); matches = hash === t.txHash; } catch (e) { hash = 'hash-failed:' + e.message.slice(0, 40); }
  const pub = (typeof tx.getPublicCallRequests === 'function' ? tx.getPublicCallRequests() : []) ?? [];
  if (matches) ok++;
  console.log(`blk ${String(t.blockNumber).padEnd(6)} ${String(t.outcome).padEnd(8)} `
    + `bytes=${String(buf.length).padEnd(7)} Tx.fromBuffer=OK  recomputedHashMatches=${matches}  `
    + `publicCallRequests=${pub.length}`);
}
console.log(`\n${ok}/${sample.length} store bodies decoded to a Tx whose RECOMPUTED hash is the key they were fetched by`);
