import { readFileSync } from 'node:fs';
import { Tx } from '@aztec/stdlib/tx';
import { BarretenbergSync } from '@aztec/bb.js';
await BarretenbergSync.initSingleton();
const BASE='https://aztec-labs-snapshots.com/testnet/txs';
const PATH='aztec-11155111-1821665230-0xd73a91bdcf6891c7642f3e460036e1ef2cc23178';
const snap=JSON.parse(readFileSync('client/fixtures/chain/aztec-testnet/snapshot.json','utf8'));
const pick=(o,n,step=1)=>snap.transactions.filter(t=>t.outcome===o).filter((_,i)=>i%step===0).slice(0,n);
for (const [name,list] of Object.entries({replayed:pick('replayed',24), pruned:pick('pruned',30,25)})) {
  const dist={}; let n=0;
  for (const t of list) {
    const r=await fetch(`${BASE}/${PATH}/txs/${t.txHash}.bin`); if(!r.ok) continue;
    const tx=Tx.fromBuffer(Buffer.from(await r.arrayBuffer())); n++;
    const c=tx.numberOfPublicCalls();
    dist[c]=(dist[c]??0)+1;
  }
  console.log(`${name.padEnd(9)} decoded=${n} numberOfPublicCalls distribution=${JSON.stringify(dist)}`);
}
