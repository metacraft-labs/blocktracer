import { readFileSync, writeFileSync } from 'node:fs';
import { bodyUrl, bareHash, storeBasePath } from '../tools/chain/backfill-bodies.mjs';
const snap = JSON.parse(readFileSync('client/fixtures/chain/aztec-testnet/snapshot.json','utf8'));
const p = snap.provenance;
const basePath = storeBasePath({ l1ChainId: p.l1ChainId, rollupVersion: p.rollupVersion,
                                 l1ContractAddresses: { rollupAddress: p.rollupAddress } });
const base = 'https://aztec-labs-snapshots.com/testnet/txs';
const txs = snap.transactions.slice().sort((a,b)=>a.blockNumber-b.blockNumber);
console.log(`population: ${txs.length} historic testnet transactions, blocks ${txs[0].blockNumber}..${txs[txs.length-1].blockNumber}`);
console.log(`store: ${base}/${basePath}/txs/`);

async function get(url){
  try{ const r=await fetch(url);
    if(!r.ok) return {status:r.status,len:0,lead:null};
    const b=Buffer.from(await r.arrayBuffer());
    return {status:r.status,len:b.length,lead:b.subarray(0,32).toString('hex')};
  }catch(e){ return {status:0,err:e.message,len:0,lead:null}; }
}
const cls=(t,r)=> r.status===404?'absent'
  : r.status!==200?`unavailable(${r.status}${r.err?':'+r.err:''})`
  : r.len<32?'truncated' : (r.lead===bareHash(t.txHash)?'verified':'mismatched');

const out={}, sizes=[]; let done=0, next=0; const perOutcomeExamples={};
const t0=Date.now(); const CONC=6;
await Promise.all(Array.from({length:CONC}, async ()=>{
  while(true){ const i=next++; if(i>=txs.length) return;
    const t=txs[i]; const r=await get(bodyUrl(base,basePath,t.txHash));
    const c=cls(t,r); out[c]=(out[c]??0)+1;
    if(c==='verified') sizes.push(r.len);
    else if(!perOutcomeExamples[c]) perOutcomeExamples[c]={block:t.blockNumber,tx:t.txHash,status:r.status};
    if(++done%150===0) console.log(`  ${done}/${txs.length} … ${JSON.stringify(out)}`);
  }}));
const wall=(Date.now()-t0)/1000;
console.log(`\nOUTCOMES over the full population: ${JSON.stringify(out)}`);
console.log(`non-verified examples: ${JSON.stringify(perOutcomeExamples)}`);
sizes.sort((a,b)=>a-b);
const sum=sizes.reduce((a,b)=>a+b,0);
const q=(f)=>sizes[Math.min(sizes.length-1,Math.floor(sizes.length*f))];
console.log(`bytes: total=${sum} (${(sum/1048576).toFixed(1)} MiB) mean=${Math.round(sum/sizes.length)} min=${sizes[0]} p50=${q(.5)} p75=${q(.75)} max=${sizes[sizes.length-1]}`);
console.log(`wall=${wall.toFixed(1)}s at concurrency ${CONC} -> ${(txs.length/wall).toFixed(1)} bodies/s, ${(sum/wall/1048576).toFixed(1)} MiB/s`);
console.log(`store rate limiting observed: ${out['unavailable(429)']??0}`);
writeFileSync('.probe/storefull.json', JSON.stringify({population:txs.length,outcomes:out,bytes:{total:sum,mean:Math.round(sum/sizes.length)},wallSeconds:wall},null,1));
