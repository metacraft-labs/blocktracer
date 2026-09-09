import { readFileSync } from 'node:fs';
import { bodyUrl, bareHash, storeBasePath } from '../tools/chain/backfill-bodies.mjs';

const snap = JSON.parse(readFileSync('client/fixtures/chain/aztec-testnet/snapshot.json','utf8'));
const p = snap.provenance;
const info = { l1ChainId: p.l1ChainId, rollupVersion: p.rollupVersion,
               l1ContractAddresses: { rollupAddress: p.rollupAddress } };
const basePath = storeBasePath(info);
const base = 'https://aztec-labs-snapshots.com/testnet/txs';
console.log('basePath:', basePath);
console.log('example :', bodyUrl(base, basePath, '00'.repeat(32)));
console.log('tip now : 75910   fixture tip:', snap.window.tip);

async function get(url){
  try{ const r=await fetch(url);
    if(!r.ok) return {status:r.status, bytes:null};
    const b=Buffer.from(await r.arrayBuffer()); return {status:r.status, bytes:b};
  }catch(e){ return {status:0, err:e.message, bytes:null}; }
}
// classify exactly as the tool does: leading 32 bytes must equal the requested key
function classify(txHash, r){
  if(r.status===404) return 'absent';
  if(r.status!==200) return 'unavailable('+r.status+(r.err?':'+r.err:'')+')';
  if(r.bytes.length < 32) return 'truncated';
  const lead = r.bytes.subarray(0,32).toString('hex');
  return lead === bareHash(txHash) ? 'verified' : 'mismatched';
}

// Sample evenly across the fixture's blocks, oldest to newest
const txs = snap.transactions.slice().sort((a,b)=>a.blockNumber-b.blockNumber);
const N = 40;
const step = Math.max(1, Math.floor(txs.length / N));
const sample = txs.filter((_,i)=> i % step === 0).slice(0, N);
console.log(`\nsampling ${sample.length} of ${txs.length} historic txs, blocks ${sample[0].blockNumber}..${sample[sample.length-1].blockNumber}`);

const out={}; let bytesTotal=0; const sizes=[];
for(const t of sample){
  const r = await get(bodyUrl(base, basePath, t.txHash));
  const c = classify(t.txHash, r);
  out[c]=(out[c]??0)+1;
  if(c==='verified'){ bytesTotal+=r.bytes.length; sizes.push(r.bytes.length); }
  console.log(`  blk ${String(t.blockNumber).padEnd(6)} ${t.outcome.padEnd(14)} ${c}${r.bytes?' '+r.bytes.length+'B':''}`);
}
console.log('\noutcomes:', JSON.stringify(out));
if(sizes.length){ sizes.sort((a,b)=>a-b);
  console.log(`verified bytes: total=${bytesTotal} mean=${Math.round(bytesTotal/sizes.length)} min=${sizes[0]} median=${sizes[Math.floor(sizes.length/2)]} max=${sizes[sizes.length-1]}`); }

// NEGATIVE CONTROLS
console.log('\n--- negative controls ---');
const bogus = 'ab'.repeat(32);
const nc1 = await get(bodyUrl(base, basePath, bogus));
console.log(`fabricated hash, correct prefix -> status ${nc1.status} ${nc1.bytes?nc1.bytes.length+'B':''} (want 404/non-200)`);
const wrongPath = basePath.slice(0,-1)+'0';
const nc2 = await get(bodyUrl(base, wrongPath, sample[0].txHash));
console.log(`real hash, wrong base path      -> status ${nc2.status} ${nc2.bytes?nc2.bytes.length+'B':''} (want 404/non-200)`);
